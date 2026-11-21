// HAo Studio themes — 4 themes x light/dark = 8 combinations.
//
// Standing rules (chen 2026-11-16):
// - Every change must be theme-related: all UI uses theme variables, NEVER
//   hardcoded colours. All 4 themes change together and each is verified.
// - Every change works in BOTH light and dark mode, including follow-system.
// - NO purple anywhere in any theme (the rejected neon deep-purple/pink
//   theme is gone; its replacement is deep black + cyan/ice-blue).
// - Less red: red appears ONLY where it truly means something — the LIVE
//   badge and the recording dot. Buttons/active states use the theme's
//   sophisticated accent, never saturated red.
// - Higher transparency: frosted-glass backgrounds (cards, sheets, tab bar,
//   player, settings rows) use lower alpha in all four themes; text stays
//   readable by increasing backdrop blur, never by darkening the background.
// - EXCEPTION (P1-U4): the home feature cards (搜歌 / 歌单广场 / 排行榜 /
//   听歌报告) are Kumone-style coloured artwork, not theme surfaces —
//   their colours are fixed artwork and deliberately do NOT follow the
//   theme. Everything else follows the rules above; do not "fix" the
//   cards to match the theme.
//
// Theme switching takes effect immediately everywhere (ThemeController
// rebuilds the app root with the new ThemeData; no restart, no stale
// cached colours).

import 'hao_radius.dart';
import 'package:flutter/material.dart';

/// The four HAo Studio themes. Visual style stays HAo Studio's own —
/// Pure Live's functionality is copied, never its look.
enum HaoThemeId {
  /// 苹果毛玻璃 — Apple frosted glass.
  appleGlass,

  /// 暗夜鎏金 — dark gold.
  darkGold,

  /// 清新薄荷 — fresh mint.
  freshMint,

  /// 极夜冰蓝 — polar-night ice blue.
  polarIce,
}

/// Frosted-glass + semantic colours for one theme/mode combination.
/// Read at call sites via `Theme.of(context).extension<HaoTheme>()!` or
/// `HaoTheme.of(context)`. Never hardcode a colour at a call site.
class HaoTheme extends ThemeExtension<HaoTheme> {
  const HaoTheme({
    required this.accent,
    required this.accentSoft,
    required this.surface,
    required this.surfaceStrong,
    required this.surfaceSolid,
    required this.hairline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.liveRed,
    required this.glassBlurSigma,
    required this.glassIntensity,
    required this.scaffoldBackground,
    required this.tabPill,
  });

  /// Sophisticated theme accent for buttons / active states (never red).
  final Color accent;

  /// Low-alpha accent wash (selected rows, progress fill background).
  final Color accentSoft;

  /// Frosted-glass surface: LOW alpha + strong blur (see [glassBlurSigma]).
  final Color surface;

  /// Slightly less transparent glass (sheets, player).
  final Color surfaceStrong;

  /// Opaque surface for places glass cannot be used (menus that must be
  /// fully legible over arbitrary content).
  final Color surfaceSolid;

  /// Hairline divider / border colour.
  final Color hairline;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// The ONLY red in the app: LIVE badge + recording dot. Never used for
  /// buttons or active states.
  final Color liveRed;

  /// Backdrop blur sigma for frosted glass. Higher transparency is kept
  /// readable by raising blur, never by darkening the background.
  final double glassBlurSigma;

  /// Liquid-glass intensity (chen 2026-11-21, Settings → 外观 slider):
  /// 1.0 = today's full glass, 0.0 = no glass at all (clear surfaces,
  /// no blur/frost). Scales blur sigma, surface alphas and the library
  /// optics (see HaoLiquidGlass) — never the layout.
  final double glassIntensity;

  final Color scaffoldBackground;

  /// Solid matte colour of the tab-bar resting pill (Muse app bar,
  /// chen 2026-11-20 "一模一样"): light #E4E4E4 measured off the
  /// reference frames (pill 228 on bar 249), dark #3A3A3C, clearly
  /// lighter than every dark scaffold (0–13). Opaque on purpose —
  /// the old colorBurn painter rendered nearly invisible in Skia,
  /// and a matte fill is deterministic in both renderers. Never
  /// black, never faint.
  final Color tabPill;

  static HaoTheme of(BuildContext context) =>
      Theme.of(context).extension<HaoTheme>()!;

  @override
  HaoTheme copyWith({
    Color? accent,
    Color? accentSoft,
    Color? surface,
    Color? surfaceStrong,
    Color? surfaceSolid,
    Color? hairline,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? liveRed,
    double? glassBlurSigma,
    double? glassIntensity,
    Color? scaffoldBackground,
    Color? tabPill,
  }) {
    return HaoTheme(
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      surface: surface ?? this.surface,
      surfaceStrong: surfaceStrong ?? this.surfaceStrong,
      surfaceSolid: surfaceSolid ?? this.surfaceSolid,
      hairline: hairline ?? this.hairline,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      liveRed: liveRed ?? this.liveRed,
      glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
      glassIntensity: glassIntensity ?? this.glassIntensity,
      scaffoldBackground: scaffoldBackground ?? this.scaffoldBackground,
      tabPill: tabPill ?? this.tabPill,
    );
  }

  @override
  HaoTheme lerp(ThemeExtension<HaoTheme>? other, double t) {
    if (other is! HaoTheme) return this;
    return HaoTheme(
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceStrong: Color.lerp(surfaceStrong, other.surfaceStrong, t)!,
      surfaceSolid: Color.lerp(surfaceSolid, other.surfaceSolid, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      liveRed: Color.lerp(liveRed, other.liveRed, t)!,
      glassBlurSigma:
          glassBlurSigma + (other.glassBlurSigma - glassBlurSigma) * t,
      glassIntensity:
          glassIntensity + (other.glassIntensity - glassIntensity) * t,
      scaffoldBackground: Color.lerp(
        scaffoldBackground,
        other.scaffoldBackground,
        t,
      )!,
      tabPill: Color.lerp(tabPill, other.tabPill, t)!,
    );
  }
}

/// One theme's light + dark [ThemeData]. Built from a single accent so the
/// four themes stay coherent across both modes.
class HaoThemePair {
  const HaoThemePair({required this.light, required this.dark});

  final ThemeData light;
  final ThemeData dark;
}

ThemeData _buildThemeData({
  required Brightness brightness,
  required Color accent,
  required Color onAccent,
  required Color scaffoldBackground,
  required Color surface,
  required Color surfaceStrong,
  required Color surfaceSolid,
  required Color hairline,
  required Color textPrimary,
  required Color textSecondary,
  required Color textMuted,
  required double glassBlurSigma,
  required double glassIntensity,
  required Color tabPill,
  // True while a custom background (wallpaper / background colour)
  // is active (chen 2026-11-21: 壁纸要到全局）: the scaffold and the
  // app bar go transparent so the app-root background layer shows
  // through on EVERY page, not just the tab roots.
  required bool backgroundActive,
  // Custom font family (stage 2, Beans `FontManager`): null = system
  // default. Passed to the ThemeData constructor so it lands in the
  // default text themes (ThemeData.copyWith has NO fontFamily
  // parameter — a copyWith would silently drop it).
  String? fontFamily,
}) {
  // Red is reserved for the LIVE badge / recording dot only.
  const liveRed = Color(0xFFE5484D);
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: onAccent,
    secondary: accent,
    onSecondary: onAccent,
    error: liveRed,
    onError: Colors.white,
    surface: surfaceSolid,
    onSurface: textPrimary,
  );
  return ThemeData(
    brightness: brightness,
    fontFamily: fontFamily,
    colorScheme: colorScheme,
    scaffoldBackgroundColor:
        backgroundActive ? Colors.transparent : scaffoldBackground,
    primaryColor: accent,
    appBarTheme: AppBarTheme(
      backgroundColor: backgroundActive ? Colors.transparent : surface,
      foregroundColor: textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaoRadius.panel),
        side: BorderSide(color: hairline),
      ),
    ),
    dividerColor: hairline,
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    // Generic list-row typography (settings rows and every other tab's
    // rows share it): title 16/w600 primary, subtitle 13 secondary.
    // Per-row styles that only set a colour inherit size/weight/height
    // from here, so the hierarchy holds in all 8 combinations.
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        height: 1.35,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: textSecondary,
        height: 1.45,
      ),
      iconColor: textSecondary,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colorScheme.onPrimary
            : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent
            : textMuted.withValues(alpha: 0.35),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: textMuted.withValues(alpha: 0.30),
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: 0.14),
      valueIndicatorColor: accent,
      valueIndicatorTextStyle: TextStyle(
        color: colorScheme.onPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent.withValues(alpha: 0.14)
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? accent : textSecondary,
        ),
        side: WidgetStateProperty.all(BorderSide(color: hairline)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.large)),
        ),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: accent.withValues(alpha: 0.14),
      checkmarkColor: accent,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: textSecondary,
      ),
      side: BorderSide(color: hairline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.large)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      elevation: 0,
      pressElevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.sheet)),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: textPrimary,
      ),
      contentTextStyle: TextStyle(
        fontSize: 14,
        color: textSecondary,
        height: 1.55,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? textMuted.withValues(alpha: 0.25)
              : accent,
        ),
        foregroundColor: WidgetStateProperty.all(colorScheme.onPrimary),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
        ),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.large)),
        ),
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(accent),
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaoRadius.large),
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaoRadius.large),
        borderSide: BorderSide(color: hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaoRadius.large),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      hintStyle: TextStyle(color: textMuted, fontSize: 14),
      labelStyle: TextStyle(color: textSecondary, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : textMuted,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: textPrimary),
      bodyMedium: TextStyle(color: textPrimary),
      bodySmall: TextStyle(color: textSecondary),
      titleLarge: TextStyle(color: textPrimary),
      titleMedium: TextStyle(color: textPrimary),
      titleSmall: TextStyle(color: textSecondary),
      labelLarge: TextStyle(color: textPrimary),
      labelMedium: TextStyle(color: textSecondary),
      labelSmall: TextStyle(color: textMuted),
    ),
    iconTheme: IconThemeData(color: textPrimary),
    extensions: <ThemeExtension<dynamic>>[
      HaoTheme(
        accent: accent,
        accentSoft: accent.withValues(alpha: 0.14),
        surface: surface,
        surfaceStrong: surfaceStrong,
        surfaceSolid: surfaceSolid,
        hairline: hairline,
        textPrimary: textPrimary,
        textSecondary: textSecondary,
        textMuted: textMuted,
        liveRed: liveRed,
        glassBlurSigma: glassBlurSigma,
        glassIntensity: glassIntensity,
        scaffoldBackground: scaffoldBackground,
        tabPill: tabPill,
      ),
    ],
  );
}

/// Text/icon colour on top of a custom accent: white on dark
/// accents, near-black on light ones (same split the gold and
/// mint dark-mode pairs already use for their light accents).
Color _onAccentFor(Color accent) =>
    ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : const Color(0xFF0B0B0F);

/// All four themes, each with light + dark. No purple anywhere.
/// Blue -> black (chen 2026-11-18): the two blue/cyan accents
/// (appleGlass, polarIce) are black in light mode and dark grey
/// #76767A in dark mode (black-on-black would be invisible; white
/// text on the grey is ~4.6:1). Gold and mint accents are not blue
/// and are unchanged.
class HaoThemes {
  HaoThemes._();

  static const Map<HaoThemeId, String> names = {
    HaoThemeId.appleGlass: '苹果毛玻璃',
    HaoThemeId.darkGold: '暗夜鎏金',
    HaoThemeId.freshMint: '清新薄荷',
    HaoThemeId.polarIce: '极夜冰蓝',
  };

  /// The user's custom accent (settings -> 自定义强调色) replaces the
  /// per-theme accent in BOTH modes when set; null keeps the
  /// per-theme defaults. Only accent-role usages move: liveRed,
  /// text colours and surfaces are separate slots and never change.
  static HaoThemePair of(
    HaoThemeId id, {
    String? fontFamily,
    Color? accentOverride,
    // Liquid-glass intensity (chen 2026-11-21): 1.0 = today's glass.
    double glassIntensity = 1.0,
    // Custom background active (wallpaper / background colour):
    // scaffolds + app bars go transparent (see _buildThemeData).
    bool backgroundActive = false,
  }) {
    final overrideOnAccent = accentOverride == null
        ? null
        : _onAccentFor(accentOverride);
    switch (id) {
      case HaoThemeId.appleGlass:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF000000),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFF2F2F7),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: Colors.black.withValues(alpha: 0.08),
            textPrimary: const Color(0xFF1C1C1E),
            textSecondary: const Color(0xFF3A3A3C),
            // Light-mode contrast (WCAG, on scaffold #F2F2F7): 4.75:1
            // (was 2.92:1 — below even the 3:1 large-text bar). Dark
            // mode is untouched (7.31:1 already).
            textMuted: const Color(0xFF6B6B70),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF76767A),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFF000000),
            surface: Colors.white.withValues(alpha: 0.10),
            surfaceStrong: Colors.white.withValues(alpha: 0.16),
            surfaceSolid: const Color(0xFF1C1C1E),
            hairline: Colors.white.withValues(alpha: 0.12),
            textPrimary: const Color(0xFFF5F5F7),
            textSecondary: const Color(0xFFD1D1D6),
            textMuted: const Color(0xFF98989D),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
      case HaoThemeId.darkGold:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF9A7B1E),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFFAF6EC),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: const Color(0xFFFFFDF5),
            hairline: const Color(0xFF9A7B1E).withValues(alpha: 0.18),
            textPrimary: const Color(0xFF2A2113),
            textSecondary: const Color(0xFF5C4F33),
            // Light-mode contrast (WCAG, on scaffold #FAF6EC): 4.77:1
            // (was 3.10:1). Same warm-tan hue, only darker. Dark mode
            // untouched (5.88:1 already).
            textMuted: const Color(0xFF7A6C4E),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFFD4AF37),
            onAccent: overrideOnAccent ?? const Color(0xFF0B0B0F),
            scaffoldBackground: const Color(0xFF0D0B08),
            surface: Colors.white.withValues(alpha: 0.08),
            surfaceStrong: Colors.white.withValues(alpha: 0.14),
            surfaceSolid: const Color(0xFF1D1A14),
            hairline: const Color(0xFFD4AF37).withValues(alpha: 0.22),
            textPrimary: const Color(0xFFF5EDD6),
            textSecondary: const Color(0xFFD8C9A3),
            textMuted: const Color(0xFF9A8B6B),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
      case HaoThemeId.freshMint:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF00897B),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFEFFAF6),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: const Color(0xFF00897B).withValues(alpha: 0.14),
            textPrimary: const Color(0xFF122E29),
            textSecondary: const Color(0xFF3D5A54),
            // Light-mode contrast (WCAG, on scaffold #EFFAF6): 4.76:1
            // (was 2.58:1). Same muted-teal hue, only darker. Dark
            // mode untouched (6.95:1 already).
            textMuted: const Color(0xFF58746D),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF4DD0C4),
            onAccent: overrideOnAccent ?? const Color(0xFF0B0B0F),
            scaffoldBackground: const Color(0xFF07110F),
            surface: Colors.white.withValues(alpha: 0.09),
            surfaceStrong: Colors.white.withValues(alpha: 0.15),
            surfaceSolid: const Color(0xFF122622),
            hairline: Colors.white.withValues(alpha: 0.12),
            textPrimary: const Color(0xFFE6F7F3),
            textSecondary: const Color(0xFFB9D9D2),
            textMuted: const Color(0xFF7FA39B),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
      case HaoThemeId.polarIce:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF000000),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFEEF6FB),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: Colors.black.withValues(alpha: 0.14),
            textPrimary: const Color(0xFF0F2436),
            textSecondary: const Color(0xFF3A5568),
            // Light-mode contrast (WCAG, on scaffold #EEF6FB): 4.93:1
            // (was 2.67:1). Same steel-blue hue, only darker. Dark
            // mode untouched (6.76:1 already).
            textMuted: const Color(0xFF4F6E84),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF76767A),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFF050B12),
            surface: Colors.white.withValues(alpha: 0.08),
            surfaceStrong: Colors.white.withValues(alpha: 0.14),
            surfaceSolid: const Color(0xFF0E1E2E),
            hairline: Colors.white.withValues(alpha: 0.20),
            textPrimary: const Color(0xFFE8F4FC),
            textSecondary: const Color(0xFFB4D2E6),
            textMuted: const Color(0xFF7D9BB0),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
    }
  }
}
